# Copyright (C) 2009 Cognifide
# 
# This file is part of Taskboard.
# 
# Taskboard is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# Taskboard is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with Taskboard. If not, see <http://www.gnu.org/licenses/>.

class TaskboardController < JuggernautSyncController
  include ApplicationHelper
  
  before_filter :authorize_read_only, :except => ["show", "index", "get_taskboard", "load_burndown"]

  def index
    redirect_to :controller => 'project', :action => 'index'
  end

  def show
    @taskboard_id = params[:id].to_i
  end

  def add_taskboard
    if params[:project_id].blank?
      flash[:error] = "You need to specify project id!"
      redirect_to :action => 'index'
    else
      taskboard = Taskboard.new
      taskboard.name = params[:name].blank? ? Taskboard::DEFAULT_NAME : params[:name]
      taskboard.project_id = params[:project_id]
      taskboard.columns << Column.new(:name => Column::DEFAULT_NAME)
      taskboard.rows << Row.new(:name => Row::DEFAULT_NAME)
      taskboard.save!
      redirect_to :action => 'show', :id => taskboard.id
    end
  end

  def clone_taskboard
    if params[:id].empty?
      flash[:error] = "Source taskboard should be set!"
      redirect_to :action => 'index'
    else
      taskboard = Taskboard.find(params[:id].to_i)
      clonned = taskboard.clone
      clonned.name = 'Copy of ' + taskboard.name
      clonned.save!
      redirect_to :action => 'show', :id => clonned.id
    end
  end

  def get_taskboard
    render :json => Taskboard.find(params[:id].to_i).to_json
  end

  def rename_taskboard
    taskboard = Taskboard.find(params[:id].to_i)
    if not params[:name].blank?
      before = taskboard.name
      taskboard.name = params[:name]
      taskboard.save!
      render :json => sync_rename_taskboard(taskboard, { :before => before })
    else
      send_error 'Taskboard name cannot be empty!'
    end
  end

  def add_column
    column = insert_column params[:taskboard_id].to_i, params[:name]
    render :json => sync_add_column(column)
  end
  
  def reorder_columns
    column = Column.find(params[:id].to_i)
    before = column.position
    column.insert_at(params[:position].to_i)
    render :json => sync_move_column(column, { :before => before })
  end

  def rename_column
    column = Column.find(params[:id].to_i)
    if not params[:name].empty?
      before = column.name
      column.name = params[:name]
      column.save!
      render :json => sync_rename_column(column, { :before => before })
    else
      send_error 'Column name cannot be empty!'
    end  
  end
  
  def remove_column
    # first remove from list, than delete from db
    # to keep the rest of the list consistent
    column = Column.find(params[:id].to_i)
    column.remove_from_list
    Column.delete params[:id].to_i
    render :json => sync_delete_column(column)
  end
  
  def add_row
    row = insert_row params[:taskboard_id].to_i
    render :json => sync_add_row(row)
  end

  def remove_row
    # first remove from list, than delete from db
    # to keep the rest of the list consistent
    row = Row.find(params[:id].to_i)
    row.remove_from_list
    Row.delete params[:id].to_i
    render :json => sync_delete_row(row)
  end

  def add_card
    name = params[:name]
    taskboard_id = params[:taskboard_id].to_i
    column_id = params[:column_id]
    row_id = params[:row_id]
    
    if column_id.nil? or column_id == ''
      new_column = insert_column taskboard_id
      column_id = new_column.id
      sync_add_column(new_column)
    else
      column_id = params[:column_id].to_i
    end

    if row_id.nil? or row_id == ''
      row_id = Taskboard.find(taskboard_id).rows.first.id
    else
      row_id = row_id.to_i
    end
    
    cards = []
    
    begin
      if JiraParser.is_jira_url(name)
        cards = JiraParser.fetch_cards(name) 
      elsif UrlParser.is_url(name)
        cards = UrlParser.fetch_cards(name)
      else
        cards << Card.new(:taskboard_id => taskboard_id, :column_id => column_id, :row_id => row_id, :name => name)
      end
    rescue
      render :text => "{ status: 'error', message: '#{$!.message}' }"
    else
      taskboard = Taskboard.find(taskboard_id)
      issues = taskboard.cards.collect {|card| card.issue_no unless card.issue_no.nil?}

      updated_cards = cards.select{ |card|
        card.issue_no.nil? or not issues.include?(card.issue_no)
      }.each{ |card|
        card.taskboard_id = taskboard_id
        card.column_id = column_id
        card.row_id = row_id
        card.save!
        card.insert_at(1)
      }

      if updated_cards.empty?
        render :text => "{ status : 'success' }"
      else
        render :json => sync_add_cards(updated_cards)
      end
    end
  end

  def reorder_cards
    card = Card.find(params[:id].to_i)
    before = "#{card.position} @ #{card.column.name}"
    target_column_id = params[:column_id].to_i unless params[:column_id].blank?
    target_row_id = params[:row_id].to_i unless params[:row_id].blank?
    target_position = params[:position].to_i unless params[:position].blank?

    card.move_to(target_column_id, target_row_id, target_position)
    render :json => sync_move_card(card, { :before => before })
  end

  def remove_card
    # first remove from list, than delete from db
    # to keep the rest of the list consistent
    card = Card.find(params[:id].to_i)
    card.remove_from_list
    Card.delete params[:id].to_i
    render :json => sync_delete_card(card)
  end

  def load_burndown
    taskboard = Taskboard.find(params[:id].to_i)
    render :text => burndown(taskboard)
  end

  private

    def insert_column taskboard_id, name = Column::DEFAULT_NAME, position = 1
      column = Column.new(:name => name, :taskboard_id => taskboard_id)
      column.save!
      column.insert_at(position)
      return column
    end

    def insert_row taskboard_id, name = Row::DEFAULT_NAME, position = nil
      position ||= Taskboard.find(taskboard_id).rows.size + 1
      row = Row.new(:name => name, :taskboard_id => taskboard_id)
      row.save!
      row.insert_at(position)
      return row
    end

    def send_error message = 'Error!'
      render :text => "{ status: 'error', message: #{message.to_json} }"
    end
end
